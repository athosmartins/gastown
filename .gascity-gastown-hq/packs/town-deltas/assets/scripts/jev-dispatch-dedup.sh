#!/usr/bin/env bash
# jev-dispatch-dedup.sh (ga-55gq9p, epic ga-aijm2v -- "bead ja resolvida ou duplicada" do Jev,
# modo SOMBRA): entry point of the `jev-dispatch-dedup` gc order. The logic lives in
# $CITY/scripts/jev_dispatch_dedup_experiment.py (see its header for the recall + 3-atomic-
# question mechanism, the offline 32-pair calibration, and the third-state discipline); this
# wrapper only fixes the environment an order does not inherit, bounds the run, and keeps a
# one-line-per-run log. Same shape as jev-gate-fail-categoria.sh on purpose.
#
# SHADOW = nothing about any dispatch changes: the consumer only READS (pilot-dispatcher.jsonl,
# `bd show`, `recall`) and writes its own experiment log lines. No real dispatch is held or
# rerouted because of anything this script logs -- it runs strictly AFTER the Pilot already
# dispatched the bead.
#
# Hard bound: `timeout` kills a stuck run; the single-instance lock is an flock inside the
# python script, which the kernel releases when the process dies, so a killed run never leaves
# a stale lock. The order's cooldown (1h) is far above a normal run.
#
# Off switches, same shape as this city's other guards: JEV_DISPATCH_DEDUP_ENABLED=0, or the
# file .gc/logs/jev-dispatch-dedup.disabled (both handled inside
# jev_dispatch_dedup_experiment.py).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PY="${JEV_DISPATCH_DEDUP_PYTHON:-python3}"
SCRIPT="${JEV_DISPATCH_DEDUP_SCRIPT:-$CITY/scripts/jev_dispatch_dedup_experiment.py}"
LOG_FILE="${JEV_DISPATCH_DEDUP_LOG_FILE:-$CITY/.gc/logs/jev-dispatch-dedup.log}"
TIMEOUT_S="${JEV_DISPATCH_DEDUP_TIMEOUT_S:-900}"
LIMIT="${JEV_DISPATCH_DEDUP_LIMIT:-30}"
LOG_MAX_BYTES=2097152

# An order does not inherit an interactive PATH: bd + secret (Cloudflare credential) + recall
# live in ~/.local/bin, python3 + timeout in /opt/homebrew/bin.
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
