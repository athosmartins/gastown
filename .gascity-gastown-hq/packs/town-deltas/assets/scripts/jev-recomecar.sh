#!/usr/bin/env bash
# jev-recomecar.sh (ga-aijm2v.8 -- "hora de recomecar", Jev in SHADOW, OFFLINE): entry point of the
# `jev-recomecar` gc order. The logic lives in $CITY/scripts/jev_recomecar_experiment.py (see its
# header for what a boundary is, the three-state discipline and how "reusou" is measured without a
# judge); this wrapper only fixes the environment an order does not inherit, bounds the run and keeps
# a one-line-per-run log.
#
# SHADOW + OFFLINE = no live session changes in any way: the consumer only READS the transcripts
# Claude Code already wrote (~/.claude/projects/*/*.jsonl), asks Jev, and appends rows to the shared
# experiment log. It never runs gc/tmux/bd (its selftest forbids subprocess for a whole run).
#
# Hard bound: `timeout` kills a stuck run, so the single-instance lock (a pid in a directory, owned
# by the python process) is reclaimed by the next run instead of held by a hung process. The order's
# cooldown (15m) is far above a normal run: a run only re-reads transcripts that CHANGED (state cache)
# and calls Jev ~1 s per new boundary (3 questions), measured live 25/09 (8 boundaries = 34 s
# including a cold scan of 808 files). The very first run backfills 72h and is spread over a few
# runs by MAX_EVAL / the internal budget -- rows are never lost or duplicated (the log is the
# idempotency source of truth).
#
# Off switches, same shape as this city's other guards: JEV_RECOMECAR_ENABLED=0, or the file
# $GC_PACK_STATE_DIR/jev-recomecar.disabled (handled inside the python script).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PY="${JEV_RECOMECAR_PYTHON:-python3}"
SCRIPT="${JEV_RECOMECAR_SCRIPT:-$CITY/scripts/jev_recomecar_experiment.py}"
LOG_FILE="${JEV_RECOMECAR_LOG_FILE:-$CITY/.gc/logs/jev-recomecar.log}"
TIMEOUT_S="${JEV_RECOMECAR_TIMEOUT_S:-270}"
LOG_MAX_BYTES=2097152

# An order does not inherit an interactive PATH: `secret` (the Cloudflare credential, read once per
# run) lives in ~/.local/bin, python3 + timeout in /opt/homebrew/bin.
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
