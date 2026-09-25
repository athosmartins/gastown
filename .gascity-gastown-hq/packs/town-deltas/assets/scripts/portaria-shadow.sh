#!/usr/bin/env bash
# portaria-shadow.sh (ga-aijm2v.4 -- Portaria do Jev v1, modo SOMBRA): entry point of the
# `portaria-shadow` gc order. The logic lives in $CITY/scripts/portaria_shadow.py (see its header
# for the cascade, the three outcomes and why bead.* events cannot say who acted); this wrapper
# only fixes the environment an order does not inherit, bounds the run, and keeps a one-line-per-
# run log.
#
# SHADOW = nothing about any delivery changes: the consumer only READS (events.jsonl, the nudge
# queue, `bd show` / `bd comments`) and writes its own state + the experiment log. It replaces the
# F1 order (mayor-inbox-jev-triage), which archived mail AFTER delivery and is switched off.
#
# Hard bound: `timeout` kills a stuck run so the single-instance lock (a pid in a directory) is
# reclaimed by the next run instead of held by a hung process. The order's cooldown (5m) is far
# above a normal run (tens of seconds: one Jev call per new delivery, ~2-5 s each; see the
# "seconds" field in the log).
#
# Off switches, same shape as this city's other guards: PORTARIA_ENABLED=0, or the file
# $GC_PACK_STATE_DIR/portaria-shadow.disabled (handled inside portaria_shadow.py).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PY="${PORTARIA_PYTHON:-python3}"
SCRIPT="${PORTARIA_SCRIPT:-$CITY/scripts/portaria_shadow.py}"
LOG_FILE="${PORTARIA_LOG_FILE:-$CITY/.gc/logs/portaria-shadow.log}"
TIMEOUT_S="${PORTARIA_TIMEOUT_S:-270}"
LOG_MAX_BYTES=2097152

# An order does not inherit an interactive PATH: bd + secret (Cloudflare credential) live in
# ~/.local/bin, python3 + timeout in /opt/homebrew/bin.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

out=$(timeout "$TIMEOUT_S" "$PY" "$SCRIPT" run 2>&1)
rc=$?
[ "$rc" -eq 124 ] && out="TIMEOUT after ${TIMEOUT_S}s ${out}"
printf '%s rc=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(printf '%s' "$out" | tail -c 1500 | tr '\n' ' ')" >> "$LOG_FILE" 2>/dev/null || true
echo "$out"
exit "$rc"
