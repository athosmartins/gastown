#!/usr/bin/env bash
# nudge-stranded-census.sh — order entrypoint for nudge-stranded-census.py (ga-9uv1xps.3).
# READ-ONLY: it never passes --apply (the census has none). Its exit code is the order's exit code:
# 0 nothing to look at, 1 STRANDED-INFO (see docs/nudge-stranded-census.md), 2 cannot tell.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"
exec python3 "$HERE/nudge-stranded-census.py" --city "$CITY" --log "$STATE_DIR/nudge-stranded-census.jsonl" "$@"
