#!/usr/bin/env bash
# gate-lane-weekly.sh — ga-atsahv item 4. Run weekly by orders/gate-lane-weekly.toml: tallies how many gate
# rounds the DOC/TEST fast lane saved (reads .gc/quality-gate.jsonl, read-only), appends the tally to
# .gc/gate-lane-tally.jsonl and sends ONE notify line. No mail, no bead. See gate-lane-tally.py.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
exec python3 "$HERE/../gate-lane-tally.py" --weekly --days 7
