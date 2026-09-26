#!/usr/bin/env bash
# jev-quem-pensa.sh (ga-aijm2v.9 -- "quem pensa" do Jev, modo SOMBRA): entry point of the
# `jev-quem-pensa` gc order. The logic lives in $CITY/scripts/jev_quem_pensa_experiment.py (see
# its header for the two experiments, the pool filter and why it joins gate outcomes offline);
# this wrapper only fixes the environment an order does not inherit, bounds the run, and keeps a
# one-line-per-run log.
#
# SHADOW = nothing about any session changes: the consumer only READS (quality-gate.jsonl,
# `bd show` / `bd comments`, git) and writes its own experiment log lines. The model pools and
# repairs actually use stays Sonnet.
#
# Hard bound: `timeout` kills a stuck run; the single-instance lock is an flock inside the python
# script, which the kernel releases when the process dies, so a killed run never leaves a stale
# lock. The order's cooldown (1h) is far above a normal run (tens of seconds to ~2 min while the
# 4-day backlog drains at --limit per run).
#
# Off switches, same shape as this city's other guards: JEV_QUEM_PENSA_ENABLED=0, or the file
# .gc/logs/jev-quem-pensa.disabled (both handled inside jev_quem_pensa_experiment.py).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PY="${JEV_QUEM_PENSA_PYTHON:-python3}"
SCRIPT="${JEV_QUEM_PENSA_SCRIPT:-$CITY/scripts/jev_quem_pensa_experiment.py}"
LOG_FILE="${JEV_QUEM_PENSA_LOG_FILE:-$CITY/.gc/logs/jev-quem-pensa.log}"
TIMEOUT_S="${JEV_QUEM_PENSA_TIMEOUT_S:-900}"
LIMIT="${JEV_QUEM_PENSA_LIMIT:-40}"
LOG_MAX_BYTES=2097152

# An order does not inherit an interactive PATH: bd + secret (Cloudflare credential) live in
# ~/.local/bin, python3 + timeout in /opt/homebrew/bin.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

# Low CPU priority: this city's machine saturates, and this job is never urgent.
out=$(nice -n 10 timeout "$TIMEOUT_S" "$PY" "$SCRIPT" run --limit "$LIMIT" 2>&1)
rc=$?
[ "$rc" -eq 124 ] && out="TIMEOUT after ${TIMEOUT_S}s ${out}"
printf '%s rc=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(printf '%s' "$out" | tail -c 1500 | tr '\n' ' ')" >> "$LOG_FILE" 2>/dev/null || true
echo "$out"
exit "$rc"
