#!/usr/bin/env bash
# nudge-state-hygiene.sh — order entrypoint for the two ga-9uv1xps loose ends of the engine's nudge state:
#   1. nudge-pollers-prune.py     prune <city>/.gc/nudges/pollers/ (dead poller stems older than 7 d)
#   2. nudge-stranded-census.py   READ-ONLY census of PENDING nudges fenced to a closed session
# They are independent: one failing never skips the other. The exit code is the WORST of the two
# (0 ok, 1 something to look at, 2 cannot tell), so a census alarm is not hidden by a clean prune and vice versa.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"

python3 "$HERE/nudge-pollers-prune.py" --apply --city "$CITY" --log "$STATE_DIR/nudge-pollers-prune.jsonl" "$@"
rc_prune=$?
python3 "$HERE/nudge-stranded-census.py" --city "$CITY" --log "$STATE_DIR/nudge-stranded-census.jsonl"
rc_census=$?

# vazio -> nunca (os dois rc existem sempre); falhou -> um rc fora de 0/1/2 (ex.: 126/127/signal) conta como 2, nunca como 0
norm() { case "$1" in 0|1|2) echo "$1" ;; *) echo 2 ;; esac; }
rc_prune="$(norm "$rc_prune")"; rc_census="$(norm "$rc_census")"
rc=$rc_prune; [ "$rc_census" -gt "$rc" ] && rc=$rc_census
exit "$rc"
