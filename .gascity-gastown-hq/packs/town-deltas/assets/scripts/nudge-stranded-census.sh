#!/usr/bin/env bash
# nudge-stranded-census.sh — order entrypoint for nudge-stranded-census.py (ga-9uv1xps.3).
# It never writes the nudge queue or a bead, and it never passes --apply (the census has none). It does pass --notify: the
# order's exit code alone reaches nobody (see the header of the .py), so an ALARM or a "cannot tell" is delivered through
# `notify`, with the dedupe / cooldown ledger and the run log under STATE_DIR. Exit code: 0 clean, 1 STRANDED-INFO,
# 2 cannot tell, 3 a notice could not be delivered (docs/nudge-stranded-census.md).
# -B -I: no bytecode written next to the script, no cwd/user-site imports (the script only needs the standard library).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"
exec python3 -B -I "$HERE/nudge-stranded-census.py" --notify --city "$CITY" --state-dir "$STATE_DIR" \
  --log "$STATE_DIR/nudge-stranded-census.jsonl" "$@"
